import React, { useState } from 'react';
import {
	AppBar,
	Tab,
	Tabs,
	Toolbar,
	IconButton,
	Drawer,
	Box,
	List,
	ListItem,
	ListItemText,
} from '@mui/material';
import MenuIcon from '@mui/icons-material/Menu';
import logo192 from '../assets/logo192.png';
import About from './About';
import Contact from './Contact';
import Portfolio from './Portfolio';
import Skills from './Skills';
import Footer from './Footer';
import Landing from './Landing';
import { InitialIcon } from '../utils/Util';

function Main() {
	const [drawerOpen, setDrawerOpen] = useState(false);

	const handleDrawerToggle = () => {
		setDrawerOpen(!drawerOpen);
	};

	const drawerLinks = [
		{ label: 'About', href: '#about' },
		{ label: 'Skills', href: '#skills' },
		{ label: 'Portfolio', href: '#portfolio' },
		{ label: 'Contact', href: '#contact' },
	];

	return (
		<>
			<Box
				sx={{
					backgroundColor: '#0D2F4B',
					'@media (max-width: 600px)': { backgroundColor: '#0D2F4B' },
				}}
			>
				{/* Content */}

				<AppBar position="static" sx={{ backgroundColor: '#0D2F4B' }}>
					<Toolbar>
						<IconButton
							color="inherit"
							edge="start"
							onClick={handleDrawerToggle}
							sx={{ mr: 2, display: { sm: 'none' } }}
						>
							<MenuIcon />
						</IconButton>
						<InitialIcon initials="E" />
						{/* <img src={ini} alt="Logo" style={{ height: '50px' }} /> */}
						<Box sx={{ flexGrow: 1, display: { xs: 'none', sm: 'block' } }}>
							<Tabs>
								<Tab
									label="About"
									href="#about"
									sx={{
										color: '#fbfbfb',
										fontWeight: 'bold',
										fontSize: '18px',
									}}
								/>
								<Tab
									label="Skills"
									href="#skills"
									sx={{
										color: '#fbfbfb',
										fontWeight: 'bold',
										fontSize: '18px',
									}}
								/>
								<Tab
									label="Portfolio"
									href="#portfolio"
									sx={{
										color: '#fbfbfb',
										fontWeight: 'bold',
										fontSize: '18px',
									}}
								/>
								<Tab
									label="Contact"
									href="#contact"
									sx={{
										color: '#fbfbfb',
										fontWeight: 'bold',
										fontSize: '18px',
									}}
								/>
							</Tabs>
						</Box>
					</Toolbar>
				</AppBar>
				<Drawer
					anchor="left"
					open={drawerOpen}
					onClose={handleDrawerToggle}
					sx={{ display: { sm: 'none' } }}
				>
					<List>
						{drawerLinks.map((link, index) => (
							<ListItem
								key={index}
								onClick={() => window.location.replace('/' + link.href)}
							>
								<ListItemText primary={link.label} />
							</ListItem>
						))}
					</List>
				</Drawer>
				<Landing />
				<Box id="about" sx={{ mt: { xs: 30, sm: 0 } }}>
					<About />
				</Box>
				<Box id="skills">
					<Skills />
				</Box>
				<Box id="portfolio">
					<Portfolio />
				</Box>
				<Box id="contact">
					<Contact />
				</Box>
				<Footer />
			</Box>
		</>
	);
}

export default Main;
