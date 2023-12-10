// Portfolio.tsx
import React from 'react';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Grid from '@mui/material/Grid';
import Card from '@mui/material/Card';
import CardMedia from '@mui/material/CardMedia';
import CardActionArea from '@mui/material/CardActionArea';
import Button from '@mui/material/Button';

import portfolio1 from '../assets/images/portfolio1.jpg';

const PortfolioItem: React.FC<{
	title: string;
	description: string;
	imageUrl: any;
}> = ({ title, description, imageUrl }) => {
	return (
		<Card
			sx={{
				position: 'relative',
				height: '30vw',
				width: '30vw',
				borderRadius: '20px',
			}}
		>
			<CardActionArea>
				<CardMedia
					component="img"
					image={imageUrl}
					alt={title}
					sx={{ height: '30vw', width: '30vw', objectFit: 'cover' }}
				/>
				<Box
					sx={{
						position: 'absolute',
						top: '50%',
						left: '50%',
						transform: 'translate(-50%, -50%)',
						height: '30vw',
						width: '30vw',
						backgroundColor: '#0D2F4B',
						alignItems: 'center',
						justifyContent: 'center',
						padding: '24px',
						opacity: 0,
						'&:hover': { opacity: 1 },
					}}
				>
					<Typography
						variant="h3"
						sx={{ color: '#fbfbfb', textAlign: 'center' }}
					>
						{title}
					</Typography>
					<Typography
						variant="body1"
						sx={{ color: '#fbfbfb', textAlign: 'center' }}
					>
						{description}
					</Typography>
					<Button
						variant="contained"
						sx={{
							mt: 2,
							backgroundColor: '#fec86a',
							color: '#34353b',
							'&:hover': { backgroundColor: '#cc9e4e' },
						}}
					>
						See More
					</Button>
				</Box>
			</CardActionArea>
		</Card>
	);
};

const Portfolio: React.FC = () => {
	// Replace with your actual portfolio items
	const portfolioItems = [
		{
			title: 'Project 1',
			description: 'Description 1',
			imageUrl: portfolio1,
		},
		{
			title: 'Project 2',
			description: 'Description 1',
			imageUrl: portfolio1,
		},
		{
			title: 'Project 3',
			description: 'Description 1',
			imageUrl: portfolio1,
		},
		// ... other portfolio items
	];

	return (
		<Box sx={{ padding: '50px 100px', backgroundColor: '#0D2F4B' }}>
			<Typography
				variant="h1"
				sx={{
					fontSize: '56px',
					fontWeight: 700,
					color: '#fbfbfb',
					fontFamily: 'Libre Baskerville, serif',
					marginBottom: '30px',
				}}
			>
				Portfolio
			</Typography>
			<Box
				sx={{
					height: '2.5px',
					width: '80px',
					backgroundColor: '#fec86a',
					marginRight: '32px',
				}}
			/>
			<Grid container spacing={2} justifyContent="center" marginTop={2}>
				{portfolioItems.map((item, index) => (
					<Grid item key={index}>
						<PortfolioItem
							title={item.title}
							description={item.description}
							imageUrl={item.imageUrl}
						/>
					</Grid>
				))}
			</Grid>
		</Box>
	);
};

export default Portfolio;
