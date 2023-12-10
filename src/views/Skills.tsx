// Skills.tsx
import React from 'react';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Grid from '@mui/material/Grid';
import Paper from '@mui/material/Paper';
import { images } from '../utils/Util';

const SkillCard: React.FC<{ title: string; imageUrl: any }> = ({
	title,
	imageUrl,
}) => {
	return (
		<Paper
			sx={{
				height: '20vw',
				width: '20vw',
				backgroundColor: '#0D2F4B',
				borderRadius: '20px',
				display: 'flex',
				flexDirection: 'column',
				alignItems: 'center',
				justifyContent: 'center',
				gap: '2.5vh',
				'&:hover': { backgroundColor: '#fec86a' },
			}}
		>
			<img
				src={imageUrl}
				alt={title}
				style={{ height: '7.5vw', width: '7.5vw' }}
			/>
			<Typography variant="h6" sx={{ color: '#fbfbfb' }}>
				{title}
			</Typography>
		</Paper>
	);
};

const Skills: React.FC = () => {
	// Replace with your actual skills and image paths
	const skills = [
		{ title: 'Android', imageUrl: images.android },
		{ title: 'Aws', imageUrl: images.aws },
		{ title: 'Css', imageUrl: images.css },
		{ title: 'Flask', imageUrl: images.flask },
		{ title: 'Git', imageUrl: images.git },
		{ title: 'Java', imageUrl: images.java },
		{ title: 'Javascript', imageUrl: images.js },
		{ title: 'MySQL', imageUrl: images.mysql },
		{ title: 'NodeJS', imageUrl: images.nodejs },
		{ title: 'Python', imageUrl: images.python },
		{ title: 'React', imageUrl: images.react },
		// ... other skills
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
				My Skills
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
				{skills.map((skill, index) => (
					<Grid item key={index}>
						<SkillCard title={skill.title} imageUrl={skill.imageUrl} />
					</Grid>
				))}
			</Grid>
		</Box>
	);
};

export default Skills;
